defmodule PlatformWeb.LivekitWebhookVoice1to1Test do
  @moduledoc """
  `room_finished` for a Voice tab 1:1 session versus a DM call in the same
  shared room `"space-<dm id>"` (task 01a174e2 stage 1).

  `async: false`: the summary provider (`:meetings_summary`), its HTTP client
  (`:anthropic_req_client`), the API key env var and LiveKit config are all
  global. A REAL (stubbed) provider is wired on purpose: with the test
  default `provider: :none` no summary could ever post, and a "no summary"
  assertion would hold whether or not the voice check exists.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Platform.AsyncAssertions

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Meetings
  alias Platform.Repo

  @path "/api/webhooks/livekit"
  @api_key_env "LIVEKIT_VOICE_1TO1_TEST_ANTHROPIC_KEY"
  @meeting_sources ~w(meeting_summarizer meeting_summarizer_fallback meeting_transcription_failure)

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    previous_livekit = Application.get_env(:platform, :livekit, [])
    previous_summary = Application.get_env(:platform, :meetings_summary)

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    # Twirp calls (CreateRoom etc.) answer {} and go nowhere.
    Application.put_env(
      :platform,
      :livekit_req_client,
      Req.new(plug: {Req.Test, :voice_1to1_livekit})
    )

    Req.Test.stub(:voice_1to1_livekit, fn conn -> Req.Test.json(conn, %{}) end)

    System.put_env(@api_key_env, "sk-voice-1to1-test")

    Application.put_env(:platform, :meetings_summary, %{
      provider: :anthropic,
      model: "claude-voice-1to1-test",
      base_url: nil,
      api_key_env: @api_key_env,
      max_tokens: 2048,
      temperature: 0.3
    })

    Application.put_env(
      :platform,
      :anthropic_req_client,
      Req.new(plug: {Req.Test, :voice_1to1_summary_llm})
    )

    test_pid = self()

    # Every summary LLM call is reported to the test, so "the summary path
    # ran" is a message, not an inference from transcript state.
    Req.Test.stub(:voice_1to1_summary_llm, fn conn ->
      send(test_pid, :summary_llm_called)

      Req.Test.json(conn, %{
        "id" => "msg_voice_1to1",
        "model" => "claude-voice-1to1-test",
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => "## Summary\n\nThey talked."}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })
    end)

    on_exit(fn ->
      Application.put_env(:platform, :livekit, previous_livekit)
      Application.delete_env(:platform, :livekit_req_client)
      Application.delete_env(:platform, :anthropic_req_client)
      System.delete_env(@api_key_env)

      if previous_summary,
        do: Application.put_env(:platform, :meetings_summary, previous_summary),
        else: Application.delete_env(:platform, :meetings_summary)
    end)

    user = user!()
    agent = agent!()
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)
    {:ok, room} = Meetings.ensure_room(dm.id)

    %{user: user, dm: dm, room: room, room_name: room.livekit_room_name}
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "voice-1to1-#{n}@example.com",
      name: "Voice OneToOne #{n}",
      oidc_sub: "oidc-voice-1to1-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{slug: "voice-1to1-agent-#{n}", name: "Agent #{n}", status: "active"})
    |> Repo.insert!()
  end

  defp event(conn, event, room_name, extra \\ %{}) do
    payload =
      Map.merge(
        %{"event" => event, "room" => %{"name" => room_name, "sid" => "RM_voice_1to1"}},
        extra
      )

    post(conn, @path, payload)
  end

  defp segments(user, texts) do
    texts
    |> Enum.with_index()
    |> Enum.map(fn {text, i} ->
      %{
        "participant_identity" => "user:" <> user.id,
        "speaker_name" => user.name,
        "text" => text,
        "start_time" => 1000 * i,
        "end_time" => 1000 * i + 900,
        "language" => "en",
        "final" => true
      }
    end)
  end

  defp meeting_notices(space_id) do
    from(m in Message, where: m.space_id == ^space_id and m.content_type == "system")
    |> Repo.all()
    |> Enum.filter(&((&1.metadata || %{})["source"] in @meeting_sources))
  end

  defp summaries(space_id) do
    space_id
    |> meeting_notices()
    |> Enum.filter(&(&1.metadata["source"] == "meeting_summarizer"))
  end

  defp open_rows(room_name) do
    room_name
    |> Meetings.list_transcripts_for_room()
    |> Enum.filter(&(&1.status in ["recording", "processing"]))
  end

  defp stored_room(room), do: Repo.reload!(room)

  # ── Voice alone ─────────────────────────────────────────────────────────

  describe "room_finished on a voice_1to1 room" do
    test "posts no summary or failure notice, leaves no open row and clears the mode",
         %{conn: conn, user: user, dm: dm, room: room, room_name: room_name} do
      {:ok, _} = Meetings.set_session_mode(room, "voice_1to1")

      assert %{"status" => "created", "transcript_id" => transcript_id} =
               conn |> event("room_started", room_name) |> json_response(201)

      build_conn()
      |> event("transcription", room_name, %{
        "segments" => segments(user, ["hey burrow", "what is on today"])
      })
      |> json_response(200)

      assert length(Meetings.get_transcript(transcript_id).segments) == 2

      assert %{"status" => "ignored", "reason" => "voice_1to1_session"} =
               build_conn() |> event("room_finished", room_name) |> json_response(200)

      # The provider is wired, so a summary path that ran would call it.
      refute_receive :summary_llm_called, 500

      assert meeting_notices(dm.id) == []
      assert open_rows(room_name) == []
      # Created during the session, so deleted rather than kept.
      assert Meetings.get_transcript(transcript_id) == nil
      refute Map.has_key?(stored_room(room).config, "session_mode")
      refute Map.has_key?(stored_room(room).config, "session_mode_at")
    end

    test "returns an older re-opened row to failed with :voice_1to1_session, posting nothing",
         %{conn: conn, user: user, dm: dm, room: room, room_name: room_name} do
      # An earlier call's row that failed; the voice session's room_started
      # re-opens it (it holds the most segments).
      {:ok, older} = Meetings.create_transcript(%{room_id: room_name, space_id: dm.id})

      {:ok, _} =
        Meetings.append_segment(older.id, %{
          "participant_identity" => "user:" <> user.id,
          "text" => "from an earlier call",
          "start_time" => 0,
          "end_time" => 900
        })

      {:ok, _} = Meetings.fail_transcript(older.id, nil, :earlier_failure)
      {:ok, _} = Meetings.set_session_mode(room, "voice_1to1")

      assert %{"transcript_id" => reopened_id} =
               conn |> event("room_started", room_name) |> json_response(201)

      assert reopened_id == older.id
      assert Meetings.get_transcript(older.id).status == "recording"

      build_conn()
      |> event("transcription", room_name, %{"segments" => segments(user, ["voice turn"])})
      |> json_response(200)

      assert %{"status" => "ignored", "reason" => "voice_1to1_session", "failed_transcripts" => 1} =
               build_conn() |> event("room_finished", room_name) |> json_response(200)

      refute_receive :summary_llm_called, 500

      row = Meetings.get_transcript(older.id)
      assert row.status == "failed"
      assert row.failure_reason =~ "voice_1to1_session"
      assert meeting_notices(dm.id) == []
      assert open_rows(room_name) == []
      refute Map.has_key?(stored_room(room).config, "session_mode")
    end
  end

  # ── A DM call ───────────────────────────────────────────────────────────

  describe "room_finished on a DM call" do
    test "runs the summary path exactly once",
         %{conn: conn, user: user, dm: dm, room_name: room_name} do
      {:ok, _} = Meetings.join_for_user(dm.id, user.id, user.name)

      assert %{"transcript_id" => transcript_id} =
               conn |> event("room_started", room_name) |> json_response(201)

      build_conn()
      |> event("transcription", room_name, %{
        "segments" => segments(user, ["agenda first", "then the roadmap"])
      })
      |> json_response(200)

      assert %{"status" => "finalized", "transcript_id" => ^transcript_id} =
               build_conn() |> event("room_finished", room_name) |> json_response(200)

      assert_receive :summary_llm_called, 5_000
      assert_eventually(fn -> length(summaries(dm.id)) == 1 end)
      assert_eventually(fn -> Meetings.get_transcript(transcript_id).status == "complete" end)

      refute_receive :summary_llm_called, 300
      assert [%{metadata: %{"transcript_id" => ^transcript_id}}] = summaries(dm.id)
    end

    test "voice then call: the join clears the mode and the call is summarized",
         %{conn: conn, user: user, dm: dm, room: room, room_name: room_name} do
      {:ok, _} = Meetings.set_session_mode(room, "voice_1to1")
      assert Meetings.voice_1to1_room?(stored_room(room))

      {:ok, %{room: joined}} = Meetings.join_for_user(dm.id, user.id, user.name)
      refute Meetings.voice_1to1_room?(joined)
      refute Meetings.voice_1to1_room?(stored_room(room))

      assert %{"transcript_id" => transcript_id} =
               conn |> event("room_started", room_name) |> json_response(201)

      build_conn()
      |> event("transcription", room_name, %{"segments" => segments(user, ["a", "b", "c"])})
      |> json_response(200)

      assert %{"status" => "finalized", "transcript_id" => ^transcript_id} =
               build_conn() |> event("room_finished", room_name) |> json_response(200)

      assert_receive :summary_llm_called, 5_000
      assert_eventually(fn -> length(summaries(dm.id)) == 1 end)
    end
  end

  # ── A DM call with an agent that cannot answer (stage 2) ────────────────

  describe "room_finished on a DM call whose agent cannot answer" do
    setup do
      previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
      previous_window = Application.get_env(:platform, :reply_failure_notice_dedupe_s)
      Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
      Application.put_env(:platform, :reply_failure_notice_dedupe_s, 0)

      on_exit(fn ->
        restore_env(:chat_agent_dispatch_mode, previous_mode)
        restore_env(:reply_failure_notice_dedupe_s, previous_window)
      end)

      router =
        Process.whereis(Platform.Chat.AttentionRouter) ||
          start_supervised!({Platform.Chat.AttentionRouter, []})

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), router)
      :ok
    end

    # External with no runtime_id: any dispatch to it posts "couldn't reply".
    test "posts exactly one summary and no 'couldn't reply' notice",
         %{conn: conn, user: user} do
      n = System.unique_integer([:positive])

      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "voice-1to1-external-#{n}",
          name: "External #{n}",
          status: "active",
          runtime_type: "external"
        })
        |> Repo.insert!()

      {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)
      {:ok, room} = Meetings.ensure_room(dm.id)
      room_name = room.livekit_room_name

      {:ok, _} = Meetings.join_for_user(dm.id, user.id, user.name)

      assert %{"transcript_id" => transcript_id} =
               conn |> event("room_started", room_name) |> json_response(201)

      build_conn()
      |> event("transcription", room_name, %{"segments" => segments(user, ["one", "two"])})
      |> json_response(200)

      assert %{"status" => "finalized", "transcript_id" => ^transcript_id} =
               build_conn() |> event("room_finished", room_name) |> json_response(200)

      assert_receive :summary_llm_called, 5_000
      assert_eventually(fn -> length(summaries(dm.id)) == 1 end)
      assert_eventually(fn -> Meetings.get_transcript(transcript_id).status == "complete" end)
      :ok = GenServer.call(Platform.Chat.AttentionRouter, :__drain__)

      assert [%{metadata: %{"transcript_id" => ^transcript_id}}] = summaries(dm.id)
      assert reply_failures(dm.id) == []

      # POSITIVE CONTROL: the same agent, asked directly, does fail visibly.
      user_p =
        Repo.get_by!(Chat.Participant,
          space_id: dm.id,
          participant_type: "user",
          participant_id: user.id
        )

      {:ok, _} =
        Chat.post_message(%{
          space_id: dm.id,
          participant_id: user_p.id,
          content_type: "text",
          content: "thanks, anything else?"
        })

      :ok = GenServer.call(Platform.Chat.AttentionRouter, :__drain__)
      assert [_] = reply_failures(dm.id)
    end
  end

  defp reply_failures(space_id) do
    from(m in Message, where: m.space_id == ^space_id)
    |> Repo.all()
    |> Enum.filter(&Platform.Chat.ReplyFailure.notice?/1)
  end

  defp restore_env(key, nil), do: Application.delete_env(:platform, key)
  defp restore_env(key, value), do: Application.put_env(:platform, key, value)

  # ── Meetings session-mode API ───────────────────────────────────────────

  describe "Meetings session mode" do
    test "set merges into config, clear removes only its keys, predicate is nil-safe",
         %{room: room} do
      {1, _} =
        Repo.update_all(from(r in Meetings.Room, where: r.id == ^room.id),
          set: [config: %{"other" => "kept"}]
        )

      room = stored_room(room)
      refute Meetings.voice_1to1_room?(room)
      refute Meetings.voice_1to1_room?(nil)
      assert Meetings.session_mode_started_at(room) == nil

      before = DateTime.utc_now()
      assert {:ok, stamped} = Meetings.set_session_mode(room, "voice_1to1")
      assert Meetings.voice_1to1_room?(stamped)
      assert stamped.config["other"] == "kept"
      assert DateTime.compare(Meetings.session_mode_started_at(stamped), before) != :lt

      assert {:ok, cleared} = Meetings.clear_session_mode(stamped)
      refute Meetings.voice_1to1_room?(cleared)
      assert stored_room(room).config == %{"other" => "kept"}

      # Clearing an unstamped room is a no-op.
      assert {:ok, %{config: %{"other" => "kept"}}} = Meetings.clear_session_mode(cleared)
    end
  end
end
