defmodule Platform.Meetings.VoiceWorkerIdentityTest do
  @moduledoc """
  Task 01a1117f stage 1: the LiveKit-dispatched voice worker (Burrow's
  livekit-agents process) resolves to its Suite agent.

  The worker joined under the livekit-agents default identity
  `"agent-" <> job.id` (`agent-AJ_…`). `parse_identity/1` answers `:unknown`
  for that, so the join inserted a second, nil-FK row named "User" beside the
  agent's invite row, the meeting rendered "Unknown participant", and every
  segment it spoke was attributed to the identity string.

  What these tests pin, one property each:

    * the legacy `agent-AJ_` join folds onto the one LiveKit-dispatched
      invite row (the named test), and a reconnect does not duplicate it;
    * no fold with two candidates, none for a transcriber-marked joiner,
      none with zero candidates;
    * a leave for the folded identity closes the agent's row;
    * the CreateDispatch metadata tells the worker its `agent:<uuid>`
      identity, id and name;
    * an agent's own speech under `agent:<uuid>` (and under the identity
      stamped on its row) is `:own_speech`;
    * a segment with no real speaker name persists with the agent's name,
      for both identity shapes, and the summary prompt says `Burrow:`.

  The `agent:<uuid>` join test at the bottom is a REGRESSION PIN, not
  coverage of this stage's code: it is green on main through
  `parse_identity/1` + `find_active_participant/3`, and the planner predicted
  that no mutation of this stage's code turns it red.

  `async: false`: LiveKit config and the injected Req client are
  application env.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.Participant
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Meetings.Transcript
  alias Platform.Repo

  @webhook "/api/webhooks/livekit"
  @livekit_agent_name "meeting-voice-agent"

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "voice-worker-identity-#{n}@example.com",
      name: "Voice Worker Identity #{n}",
      oidc_sub: "oidc-voice-worker-identity-#{n}"
    })
  end

  defp agent!(name) do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "vwi-agent-#{n}", name: name, status: "active"})
  end

  # Burrow's shape: a voice runtime declaring `client_info.livekit_agent_name`
  # (what `mix platform.seed_meeting_voice_agent` stamps), so
  # `livekit_dispatch_target/1` resolves it.
  defp burrow!(name \\ "Burrow") do
    owner = user!()
    agent = agent!(name)

    {:ok, _runtime, _raw_token} =
      Federation.register_voice_runtime(owner.id, agent, %{
        metadata: %{
          "client_info" => %{
            "features" => ["meeting_voice"],
            "livekit_agent_name" => @livekit_agent_name
          }
        }
      })

    Repo.reload(agent)
  end

  defp room! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Voice Worker Identity #{n}",
        slug: "voice-worker-identity-#{n}",
        kind: "channel"
      })

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)
    room
  end

  # The invite row exactly as `invite_participant_row/2` writes it: agent FK,
  # agent name, NO metadata identity.
  defp invite_row!(room, %Agent{} = agent) do
    {:ok, row} =
      Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

    row
  end

  defp join!(conn, room, participant) do
    payload = %{
      "event" => "participant_joined",
      "room" => %{"name" => room.livekit_room_name},
      "participant" => participant
    }

    conn |> post(@webhook, payload) |> json_response(200)
  end

  defp leave!(conn, room, participant) do
    payload = %{
      "event" => "participant_left",
      "room" => %{"name" => room.livekit_room_name},
      "participant" => participant
    }

    conn |> post(@webhook, payload) |> json_response(200)
  end

  defp active_rows(room) do
    Repo.all(from(p in Participant, where: p.room_id == ^room.id and is_nil(p.left_at)))
  end

  defp active_rows_for(room, agent) do
    Repo.all(
      from(p in Participant,
        where: p.room_id == ^room.id and p.agent_id == ^agent.id and is_nil(p.left_at)
      )
    )
  end

  defp seated_transcript!(agent, row_identity) do
    room = room!()
    row = invite_row!(room, agent)

    if row_identity do
      {:ok, _} =
        row
        |> Participant.changeset(%{metadata: %{"identity" => row_identity}})
        |> Repo.update()
    end

    {:ok, %Transcript{} = transcript} =
      Meetings.ensure_transcript(%{room_id: room.livekit_room_name, space_id: room.space_id})

    transcript
  end

  defp final_segment(identity) do
    %{"participant_identity" => identity, "text" => "hello", "final" => true}
  end

  defp burrow_transcript!(conn) do
    burrow = burrow!()
    room = room!()
    invite_row!(room, burrow)
    join!(conn, room, %{"identity" => "agent-AJ_speaker"})

    {:ok, %Transcript{} = transcript} =
      Meetings.ensure_transcript(%{room_id: room.livekit_room_name, space_id: room.space_id})

    {burrow, transcript}
  end

  defp append!(transcript, identity, speaker_name) do
    segment = %{
      "participant_identity" => identity,
      "speaker_name" => speaker_name,
      "text" => "the deploy is green",
      "start_time" => 0,
      "end_time" => 500,
      "final" => false
    }

    {:ok, updated} = Meetings.append_segment(transcript.id, segment)
    List.last(updated.segments)
  end

  # ── The fold ─────────────────────────────────────────────────────────────

  describe "legacy agent-AJ_ join" do
    test "a participant joined with the voice worker's identity shape resolves to the Burrow agent",
         %{conn: conn} do
      burrow = burrow!()
      room = room!()
      _invite = invite_row!(room, burrow)

      assert %{"status" => "ok"} = join!(conn, room, %{"identity" => "agent-AJ_testJob1"})

      assert [row] = active_rows_for(room, burrow)
      assert row.agent_id == burrow.id
      assert row.metadata["identity"] == "agent-AJ_testJob1"
      refute Enum.any?(active_rows(room), &(&1.display_name == "User"))
      assert length(active_rows(room)) == 1
    end

    test "a reconnect under the same job identity lands on the folded row", %{conn: conn} do
      burrow = burrow!()
      room = room!()
      invite = invite_row!(room, burrow)

      join!(conn, room, %{"identity" => "agent-AJ_reconnect"})
      assert %{"participant_id" => id} = join!(conn, room, %{"identity" => "agent-AJ_reconnect"})

      assert id == invite.id
      assert [_only] = active_rows(room)
    end

    test "two LiveKit-dispatched candidates: no fold, the nil-FK row is inserted as before",
         %{conn: conn} do
      a = burrow!("Burrow A")
      b = burrow!("Burrow B")
      room = room!()
      invite_row!(room, a)
      invite_row!(room, b)

      join!(conn, room, %{"identity" => "agent-AJ_ambiguous"})

      rows = active_rows(room)
      assert length(rows) == 3
      assert [stray] = Enum.filter(rows, &is_nil(&1.agent_id))
      assert stray.display_name == "User"
      assert stray.metadata["identity"] == "agent-AJ_ambiguous"

      for agent <- [a, b] do
        assert [row] = active_rows_for(room, agent)
        assert row.metadata["identity"] == nil
      end
    end

    test "an agent invited without a LiveKit dispatch target is not a candidate",
         %{conn: conn} do
      plain = agent!("Plain Agent")
      room = room!()
      invite_row!(room, plain)

      join!(conn, room, %{"identity" => "agent-AJ_nocandidate"})

      assert [row] = active_rows_for(room, plain)
      assert row.metadata["identity"] == nil
      assert Enum.any?(active_rows(room), &(is_nil(&1.agent_id) and &1.display_name == "User"))
    end

    test "a transcriber-marked joiner is never folded, even with one candidate",
         %{conn: conn} do
      burrow = burrow!()
      room = room!()
      invite_row!(room, burrow)

      join!(conn, room, %{"identity" => "agent-AJ_tx1", "name" => "meeting-transcriber"})

      assert [row] = active_rows_for(room, burrow)
      assert row.metadata["identity"] == nil

      assert Meetings.transcriber_participant?(%{
               identity: "agent-AJ_tx1",
               name: "meeting-transcriber"
             })
    end

    test "a leave for the folded identity closes the Burrow row", %{conn: conn} do
      burrow = burrow!()
      room = room!()
      invite = invite_row!(room, burrow)

      join!(conn, room, %{"identity" => "agent-AJ_leaver"})

      assert %{"status" => "ok", "participant_id" => id} =
               leave!(conn, room, %{"identity" => "agent-AJ_leaver"})

      assert id == invite.id
      assert active_rows_for(room, burrow) == []
      assert %Participant{left_at: %DateTime{}} = Repo.get!(Participant, invite.id)
    end
  end

  # ── Dispatch contract ────────────────────────────────────────────────────

  describe "CreateDispatch metadata" do
    setup do
      original = Application.get_env(:platform, :livekit, [])

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :livekit_req_client,
        Req.new(plug: {Req.Test, :voice_worker_identity_test})
      )

      on_exit(fn ->
        Application.put_env(:platform, :livekit, original)
        Application.delete_env(:platform, :livekit_req_client)
      end)

      :ok
    end

    test "tells the worker its agent:<uuid> identity, id and name" do
      burrow = burrow!()
      test_pid = self()

      Req.Test.stub(:voice_worker_identity_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, Jason.decode!(body)})
        Req.Test.json(conn, %{})
      end)

      assert :ok = Meetings.dispatch_meeting_join(burrow, "vwi-room", %{})
      assert_receive {:dispatch_body, decoded}, 1_000

      metadata = Jason.decode!(decoded["metadata"])
      assert metadata["agent_identity"] == "agent:" <> burrow.id
      assert metadata["agent_id"] == burrow.id
      assert metadata["agent_name"] == "Burrow"
      assert Meetings.parse_identity(metadata["agent_identity"]) == {:agent, burrow.id}
    end
  end

  # ── Self-exclusion ───────────────────────────────────────────────────────

  describe "self-exclusion" do
    test "a segment from agent:<id> is :own_speech for that agent" do
      agent = agent!("Burrow")
      transcript = seated_transcript!(agent, nil)

      assert {:ok, %{skipped: skipped}} =
               Meetings.deliver_transcript_segment(
                 transcript,
                 final_segment("agent:" <> agent.id)
               )

      assert {agent.id, :own_speech} in skipped
    end

    test "a segment under the identity stamped on the agent's own row is :own_speech" do
      agent = agent!("Burrow")
      transcript = seated_transcript!(agent, "agent-AJ_self")

      assert {:ok, %{skipped: skipped}} =
               Meetings.deliver_transcript_segment(transcript, final_segment("agent-AJ_self"))

      assert {agent.id, :own_speech} in skipped
    end

    test "another speaker's segment is not :own_speech" do
      agent = agent!("Burrow")
      transcript = seated_transcript!(agent, "agent-AJ_self")

      assert {:ok, %{skipped: skipped}} =
               Meetings.deliver_transcript_segment(
                 transcript,
                 final_segment("user:" <> Ecto.UUID.generate())
               )

      refute {agent.id, :own_speech} in skipped
    end
  end

  # ── Speaker name enrichment ──────────────────────────────────────────────

  describe "speaker_name enrichment at append_segment/2" do
    test "legacy agent-AJ_ identity: nil and identity-equal names persist as Burrow",
         %{conn: conn} do
      {_burrow, transcript} = burrow_transcript!(conn)

      assert append!(transcript, "agent-AJ_speaker", nil)["speaker_name"] == "Burrow"

      assert append!(transcript, "agent-AJ_speaker", "agent-AJ_speaker")["speaker_name"] ==
               "Burrow"
    end

    test "agent:<uuid> identity: nil and identity-equal names persist as Burrow", %{conn: conn} do
      {burrow, transcript} = burrow_transcript!(conn)
      identity = "agent:" <> burrow.id

      assert append!(transcript, identity, nil)["speaker_name"] == "Burrow"
      assert append!(transcript, identity, identity)["speaker_name"] == "Burrow"
    end

    test "a real speaker name is never overwritten", %{conn: conn} do
      {burrow, transcript} = burrow_transcript!(conn)

      assert append!(transcript, "agent:" <> burrow.id, "Ada")["speaker_name"] == "Ada"
      assert append!(transcript, "agent-AJ_speaker", "Ada")["speaker_name"] == "Ada"
    end

    test "an unresolvable identity keeps the transcriber's value", %{conn: conn} do
      {_burrow, transcript} = burrow_transcript!(conn)

      assert append!(transcript, "agent-AJ_someoneelse", nil)["speaker_name"] == nil
    end

    test "the summary prompt names Burrow, not agent-AJ_", %{conn: conn} do
      {burrow, transcript} = burrow_transcript!(conn)
      append!(transcript, "agent-AJ_speaker", "agent-AJ_speaker")
      append!(transcript, "agent:" <> burrow.id, nil)

      formatted = SummaryPrompt.format_segments(Meetings.get_transcript(transcript.id).segments)

      assert formatted =~ "Burrow:"
      refute formatted =~ "agent-AJ_"
      refute formatted =~ "agent:"
    end
  end

  # ── DUPLICATE_IDENTITY (task 01a1117f stage 2) ────────────────────────────
  #
  # Once the worker joins as `agent:<uuid>`, a second dispatch into the same
  # room (a pending invite clicked again: `invite_agent/3` always
  # re-dispatches) joins a second session under the SAME identity, and
  # LiveKit disconnects the older one. Its `participant_left` must not close
  # the row the newer session is now using.

  describe "duplicate identity: an older session's leave" do
    test "does not close the row after a newer session of the identity joined",
         %{conn: conn} do
      burrow = burrow!()
      room = room!()
      invite = invite_row!(room, burrow)
      identity = "agent:" <> burrow.id

      join!(conn, room, %{"identity" => identity, "sid" => "PA_first"})
      join!(conn, room, %{"identity" => identity, "sid" => "PA_second"})

      assert %{"status" => "ignored", "reason" => "superseded participant session"} =
               leave!(conn, room, %{"identity" => identity, "sid" => "PA_first"})

      assert [row] = active_rows_for(room, burrow)
      assert row.id == invite.id
      assert row.metadata["sid"] == "PA_second"

      assert %{"status" => "ok", "participant_id" => id} =
               leave!(conn, room, %{"identity" => identity, "sid" => "PA_second"})

      assert id == invite.id
      assert active_rows_for(room, burrow) == []
    end

    test "when the old leave arrives before the new join, one active row remains",
         %{conn: conn} do
      burrow = burrow!()
      room = room!()
      invite_row!(room, burrow)
      identity = "agent:" <> burrow.id

      join!(conn, room, %{"identity" => identity, "sid" => "PA_first"})

      assert %{"status" => "ok"} =
               leave!(conn, room, %{"identity" => identity, "sid" => "PA_first"})

      join!(conn, room, %{"identity" => identity, "sid" => "PA_second"})

      assert [row] = active_rows_for(room, burrow)
      assert row.metadata["sid"] == "PA_second"
    end

    test "a leave with no sid, or for a row with none recorded, still closes the row",
         %{conn: conn} do
      burrow = burrow!()
      room = room!()
      identity = "agent:" <> burrow.id

      invite_row!(room, burrow)
      join!(conn, room, %{"identity" => identity, "sid" => "PA_first"})
      assert %{"status" => "ok"} = leave!(conn, room, %{"identity" => identity})
      assert active_rows_for(room, burrow) == []

      invite_row!(room, burrow)
      join!(conn, room, %{"identity" => identity})
      assert %{"status" => "ok"} = leave!(conn, room, %{"identity" => identity, "sid" => "PA_x"})
      assert active_rows_for(room, burrow) == []
    end
  end

  # ── Regression pin (predicted non-detonation) ─────────────────────────────

  describe "regression pin: agent:<uuid> join" do
    # Green on main via parse_identity/1 + find_active_participant/3; NOT
    # coverage of this stage's fold. No mutation of this stage's code is
    # expected to turn it red.
    test "agent:<uuid> with no name lands on the one Burrow row", %{conn: conn} do
      burrow = burrow!()
      room = room!()
      invite = invite_row!(room, burrow)

      assert %{"participant_id" => id} = join!(conn, room, %{"identity" => "agent:" <> burrow.id})

      assert id == invite.id
      assert [row] = active_rows(room)
      assert row.agent_id == burrow.id
      assert row.metadata["identity"] == "agent:" <> burrow.id
    end
  end
end
