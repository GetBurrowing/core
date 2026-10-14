defmodule Platform.Meetings.RemoveAgentFromCallTest do
  @moduledoc """
  Task 01a0e906 stage 2 — `Meetings.remove_agent_from_call/3`, the host-only,
  agent-only kick that forces an agent off the LiveKit media room and closes
  its `meeting_participants` row.

  Every "0 requests" / "0 messages" assertion in this module sits beside a
  test in the same module where the same counter reads 1, so a counter that
  can never move (a stub that never ran, a query on the wrong space) fails
  here instead of reading as a refusal.

  The roster decision is pinned too: the row closes (so `say/4` refuses with
  `:not_in_room`) while the agent's `chat_participants` row survives, and
  `invite_agent/3` can bring the agent back with a fresh row.

  `async: false`: the LiveKit config and the injected Req client are
  application env.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Participant, as: MeetingParticipant
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  # ── LiveKit stub (same pattern as RemoveLivekitParticipantTest) ──────────

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

  defp ok_stub, do: stub_livekit(fn conn -> Req.Test.json(conn, %{}) end)

  defp remove_requests(acc \\ 0) do
    receive do
      {:livekit_request, "/twirp/livekit.RoomService/RemoveParticipant"} ->
        remove_requests(acc + 1)
    after
      0 -> acc
    end
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "remove-agent-#{label}-#{n}@example.com",
        name: "Remove Agent #{label} #{n}",
        oidc_sub: "oidc-remove-agent-#{label}-#{n}"
      })

    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.acme_org_id(),
        role: "member"
      })
    )

    user
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Remove Agent Space #{n}",
        slug: "remove-agent-space-#{n}",
        kind: "channel"
      })

    space
  end

  defp meeting!(space) do
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(
        Project.changeset(%Project{}, %{
          name: "Remove Agent Project #{n}",
          slug: "remove-agent-project-#{n}",
          org_id: Platform.TenancyFixtures.acme_org_id()
        })
      )

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "remove-agent-meeting-#{n}",
        name: "Remove Agent Kickoff #{n}",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    meeting
  end

  # A roster agent with a linked, activated runtime, so `invite_agent/3` and
  # `say/4` get past their runtime pre-flights.
  defp roster_agent!(space) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "removable-agent-#{n}",
        name: "Removable Agent #{n}",
        status: "active"
      })

    {:ok, _entry} = Chat.add_space_agent(space.id, agent.id, role: "member")

    owner = user!("runtime-owner")

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "remove-rt-#{System.unique_integer([:positive])}"
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

  # The row the LiveKit webhook leaves behind for an agent that arrived.
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

  defp system_messages(space_id, source \\ "meeting_agent_removed") do
    Repo.all(
      from(m in Chat.Message,
        where: m.space_id == ^space_id and m.content_type == "system",
        where: fragment("?->>'source' = ?", m.metadata, ^source)
      )
    )
  end

  defp agent_chat_membership(space_id, agent_id) do
    Repo.get_by(Chat.Participant,
      space_id: space_id,
      participant_type: "agent",
      participant_id: agent_id
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

  # ── The happy path (the positive control for every 0 below) ──────────────

  describe "host removes an agent" do
    test "one RemoveParticipant call, row closed, room told, chat membership kept",
         %{space: space, agent: agent, host: host, meeting: meeting, room: room, row: row} do
      test_pid = self()

      stub_livekit(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:remove_body, Jason.decode!(raw)})
        Req.Test.json(conn, %{})
      end)

      :ok = MeetingsPubSub.subscribe_room(room.id)

      assert {:ok, %{participant: updated, outcome: :removed}} =
               Meetings.remove_agent_from_call(meeting, row.id, host)

      assert remove_requests() == 1
      assert_received {:remove_body, body}

      assert body == %{
               "room" => room.livekit_room_name,
               "identity" => "agent:#{agent.slug}"
             }

      assert updated.id == row.id
      assert %DateTime{} = reload(row).left_at
      assert_receive {:participant_left, %MeetingParticipant{id: left_id}}
      assert left_id == row.id

      assert [message] = system_messages(space.id)
      assert message.content == "Hana Host removed #{agent.name}"

      assert message.metadata == %{
               "source" => "meeting_agent_removed",
               "agent_id" => agent.id,
               "meeting_id" => meeting.id
             }

      # The roster decision: chat-space membership is untouched.
      assert %Chat.Participant{} = agent_chat_membership(space.id, agent.id)
    end

    test "an invited-but-never-arrived row falls back to agent:<slug>",
         %{space: space, host: host, meeting: meeting, room: room} do
      %{agent: late} = roster_agent!(space)

      {:ok, row} =
        Meetings.participant_joined(room, %{display_name: late.name, agent_id: late.id})

      test_pid = self()

      stub_livekit(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:remove_body, Jason.decode!(raw)})
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{outcome: :removed}} = Meetings.remove_agent_from_call(meeting, row.id, host)
      assert_received {:remove_body, %{"identity" => identity}}
      assert identity == "agent:#{late.slug}"
    end
  end

  # ── Authorization ────────────────────────────────────────────────────────

  describe "authorization" do
    test "a non-host user is :forbidden, 0 requests, row stays active",
         %{space: space, meeting: meeting, row: row} do
      ok_stub()
      other = chat_user!(space, user!("other"), "Otto Other")

      assert Meetings.remove_agent_from_call(meeting, row.id, other) == {:error, :forbidden}
      assert remove_requests() == 0
      assert reload(row).left_at == nil
      assert system_messages(space.id) == []
    end

    test "a nil actor (a guest) is :forbidden, 0 requests, row stays active",
         %{meeting: meeting, row: row} do
      ok_stub()

      assert Meetings.remove_agent_from_call(meeting, row.id, nil) == {:error, :forbidden}
      assert remove_requests() == 0
      assert reload(row).left_at == nil
    end

    test "a meeting with no host is :forbidden even for the former host",
         %{host: host, meeting: meeting, row: row} do
      ok_stub()
      _ = set_host!(meeting, nil)

      # The STALE struct still names the host; the function must re-read.
      assert meeting.host_participant_id == host.id
      assert Meetings.remove_agent_from_call(meeting, row.id, host) == {:error, :forbidden}
      assert remove_requests() == 0
      assert reload(row).left_at == nil
    end

    test "a non-user chat participant holding the host id is :forbidden",
         %{host: host, meeting: meeting, row: row} do
      ok_stub()
      impostor = %{host | participant_type: "agent"}

      assert Meetings.remove_agent_from_call(meeting, row.id, impostor) == {:error, :forbidden}
      assert remove_requests() == 0
    end
  end

  # ── Row resolution ───────────────────────────────────────────────────────

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

      assert Meetings.remove_agent_from_call(meeting, human.id, host) == {:error, :not_an_agent}
      assert remove_requests() == 0
      assert reload(human).left_at == nil
    end

    test "a guest (nil-FK) row is :not_an_agent, 0 requests",
         %{host: host, meeting: meeting, room: room} do
      ok_stub()

      {:ok, guest} =
        Meetings.participant_joined(room, %{
          display_name: "Gus Guest",
          metadata: %{"identity" => "guest:#{Ecto.UUID.generate()}"}
        })

      assert Meetings.remove_agent_from_call(meeting, guest.id, host) == {:error, :not_an_agent}
      assert remove_requests() == 0
      assert reload(guest).left_at == nil
    end

    test "an agent row whose recorded identity is a user identity is :not_an_agent",
         %{space: space, host: host, meeting: meeting, room: room} do
      ok_stub()
      %{agent: agent} = roster_agent!(space)

      {:ok, row} =
        Meetings.participant_joined(room, %{
          display_name: agent.name,
          agent_id: agent.id,
          metadata: %{"identity" => "user:#{Ecto.UUID.generate()}"}
        })

      assert Meetings.remove_agent_from_call(meeting, row.id, host) == {:error, :not_an_agent}
      assert remove_requests() == 0
      assert reload(row).left_at == nil
    end

    test "another room's agent row is :not_found, 0 requests",
         %{host: host, meeting: meeting} do
      ok_stub()
      other_space = space!()
      %{agent: other_agent} = roster_agent!(other_space)
      other_row = other_space |> active_room!() |> arrived_agent_row!(other_agent)

      assert Meetings.remove_agent_from_call(meeting, other_row.id, host) == {:error, :not_found}
      assert remove_requests() == 0
      assert reload(other_row).left_at == nil
    end

    test "a garbage id, a missing id and nil are :not_found, 0 requests",
         %{host: host, meeting: meeting} do
      ok_stub()

      for bad <- ["not-a-uuid", "agent:some-slug", Ecto.UUID.generate(), nil, ""] do
        assert Meetings.remove_agent_from_call(meeting, bad, host) == {:error, :not_found},
               "expected :not_found for #{inspect(bad)}"
      end

      assert remove_requests() == 0
    end

    test "an already-closed row is :not_found, 0 requests",
         %{host: host, meeting: meeting, row: row} do
      ok_stub()
      row |> MeetingParticipant.changeset(%{left_at: DateTime.utc_now()}) |> Repo.update!()

      assert Meetings.remove_agent_from_call(meeting, row.id, host) == {:error, :not_found}
      assert remove_requests() == 0
    end
  end

  # ── LiveKit failures ─────────────────────────────────────────────────────

  describe "LiveKit failures" do
    test "a 500 returns the error, 1 request, row stays active, 0 messages",
         %{space: space, host: host, meeting: meeting, row: row} do
      stub_livekit(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"code" => "internal"})
      end)

      assert {:error, {:http_error, 500, _}} =
               Meetings.remove_agent_from_call(meeting, row.id, host)

      assert remove_requests() == 1
      assert reload(row).left_at == nil
      assert system_messages(space.id) == []
    end

    test "a transport error returns the error, row stays active, 0 messages",
         %{space: space, host: host, meeting: meeting, row: row} do
      stub_livekit(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Meetings.remove_agent_from_call(meeting, row.id, host)

      assert remove_requests() == 1
      assert reload(row).left_at == nil
      assert system_messages(space.id) == []
    end

    test "unconfigured LiveKit is :livekit_not_configured, 0 requests, row stays active",
         %{host: host, meeting: meeting, row: row} do
      ok_stub()
      Application.put_env(:platform, :livekit, [])

      assert Meetings.remove_agent_from_call(meeting, row.id, host) ==
               {:error, :livekit_not_configured}

      assert remove_requests() == 0
      assert reload(row).left_at == nil
    end

    test "a 404 is :already_gone and the row is still closed, room told once",
         %{space: space, host: host, meeting: meeting, row: row} do
      stub_livekit(fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"code" => "not_found"})
      end)

      assert {:ok, %{outcome: :already_gone}} =
               Meetings.remove_agent_from_call(meeting, row.id, host)

      assert remove_requests() == 1
      assert %DateTime{} = reload(row).left_at
      assert length(system_messages(space.id)) == 1
    end
  end

  # ── Re-entry ─────────────────────────────────────────────────────────────

  describe "re-entry" do
    test "say/4 is refused after removal, and invite_agent/3 brings the agent back",
         %{
           space: space,
           agent: agent,
           runtime: runtime,
           host: host,
           host_user: host_user,
           meeting: meeting,
           room: room,
           row: row
         } do
      ok_stub()

      # Positive control: before removal the in-room guard passes.
      refute Meetings.say(agent, room.livekit_room_name, "hi", ack_timeout_ms: 50) ==
               {:error, :not_in_room}

      assert {:ok, %{outcome: :removed}} = Meetings.remove_agent_from_call(meeting, row.id, host)

      assert Meetings.say(agent, room.livekit_room_name, "hi", ack_timeout_ms: 50) ==
               {:error, :not_in_room}

      PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      assert {:ok, %MeetingParticipant{} = fresh} =
               Meetings.invite_agent(room, agent, host_user)

      refute fresh.id == row.id
      assert fresh.left_at == nil

      assert_receive %Phoenix.Socket.Broadcast{event: "meeting_join", payload: payload}
      assert payload.agent_identity == "agent:#{agent.slug}"

      rows =
        Repo.all(
          from(p in MeetingParticipant,
            where: p.room_id == ^room.id and p.agent_id == ^agent.id,
            select: {p.id, is_nil(p.left_at)}
          )
        )

      assert Enum.sort(rows) == Enum.sort([{row.id, false}, {fresh.id, true}])
      assert %Chat.Participant{} = agent_chat_membership(space.id, agent.id)
    end
  end
end
